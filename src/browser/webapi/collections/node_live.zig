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

const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const Selector = @import("../selector/Selector.zig");
const Form = @import("../element/html/Form.zig");

const Mode = enum {
    tag,
    tag_name,
    tag_name_ns,
    class_name,
    name,
    all_elements,
    child_elements,
    child_tag,
    selected_options,
    links,
    anchors,
    form,
};

pub const TagNameNsFilter = struct {
    namespace: ?Element.Namespace, // null means wildcard "*"
    local_name: String,
};

const Filters = union(Mode) {
    tag: Element.Tag,
    tag_name: String,
    tag_name_ns: TagNameNsFilter,
    class_name: [][]const u8,
    name: []const u8,
    all_elements,
    child_elements,
    child_tag: Element.Tag,
    selected_options,
    links,
    anchors,
    form: *Form,

    fn TypeOf(comptime mode: Mode) type {
        @setEvalBranchQuota(2000);
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
// if the DOM is unchanged (i.e. if our _cached_version == page.version).
//
// We do something similar for indexed getter (e.g. coll[4]), by preserving the
// last node visited in the tree (implicitly by not resetting the TreeWalker).
// If the DOM version is unchanged and the new index >= the last one, we can do
// not have to reset our TreeWalker. This optimizes the common case of accessing
// the collection via incrementing indexes.

pub fn NodeLive(comptime mode: Mode) type {
    const Filter = Filters.TypeOf(mode);
    const TW = switch (mode) {
        .tag, .tag_name, .tag_name_ns, .class_name, .name, .all_elements, .links, .anchors, .form => TreeWalker.FullExcludeSelf,
        .child_elements, .child_tag, .selected_options => TreeWalker.Children,
    };
    return struct {
        _tw: TW,
        _filter: Filter,
        _last_index: usize,
        _last_length: ?u32,
        _cached_version: usize,

        const Self = @This();

        pub fn init(root: *Node, filter: Filter, page: *Page) Self {
            return .{
                ._last_index = 0,
                ._last_length = null,
                ._filter = filter,
                ._tw = TW.init(root, .{}),
                ._cached_version = page.version,
            };
        }

        pub fn length(self: *Self, page: *const Page) u32 {
            if (self.versionCheck(page)) {
                // the DOM version hasn't changed, use the cached version if
                // we have one
                if (self._last_length) |cached_length| {
                    return cached_length;
                }
                // not ideal, but this can happen if list[x] is called followed
                // by list.length.
                self._tw.reset();
                self._last_index = 0;
            }
            // If we're here, it means it's either the first time we're called
            // or the DOM version has changed. Either way, the _tw should be
            // at the start position. It's important that self._last_index == 0
            // (which it always should be in these cases), because we're going to
            // reset _tw at the end of this, _last_index should always be 0 when
            // _tw is reset. Again, this should always be the case, but we're
            // asserting to make sure, else we'll have weird behavior, namely
            // the wrong item being returned for the wrong index.
            lp.assert(self._last_index == 0, "NodeLives.length", .{ .last_index = self._last_index });

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
        pub fn getIndexed(self: *Self, value: js.Atom, page: *Page) !?*Element {
            if (value.isUint()) |n| {
                return self.getAtIndex(n, page);
            }

            const name = value.toString();
            defer value.freeString(name);

            return self.getByName(name, page) orelse return error.NotHandled;
        }

        pub fn getAtIndex(self: *Self, index: usize, page: *const Page) ?*Element {
            _ = self.versionCheck(page);
            var current = self._last_index;
            if (index <= current) {
                current = 0;
                self._tw.reset();
            }
            defer self._last_index = current + 1;

            const tw = &self._tw;
            while (self.nextTw(tw)) |el| {
                if (index == current) {
                    return el;
                }
                current += 1;
            }
            return null;
        }

        pub fn getByName(self: *Self, name: []const u8, page: *Page) ?*Element {
            if (page.document.getElementById(name, page)) |element| {
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
                const element_name = element.getAttributeSafe(comptime .wrap("name")) orelse continue;
                if (std.mem.eql(u8, element_name, name)) {
                    return element;
                }
            }
            return null;
        }

        pub fn next(self: *Self) ?*Element {
            return self.nextTw(&self._tw);
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
                    return el.getTag() == self._filter;
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
                    if (self._filter.len == 0) {
                        return false;
                    }

                    const el = node.is(Element) orelse return false;
                    const class_attr = el.getAttributeSafe(comptime .wrap("class")) orelse return false;
                    for (self._filter) |class_name| {
                        if (!Selector.classAttributeContains(class_attr, class_name)) {
                            return false;
                        }
                    }
                    return true;
                },
                .name => {
                    const el = node.is(Element) orelse return false;
                    const name_attr = el.getAttributeSafe(comptime .wrap("name")) orelse return false;
                    return std.mem.eql(u8, name_attr, self._filter);
                },
                .all_elements => return node._type == .element,
                .child_elements => return node._type == .element,
                .child_tag => {
                    const el = node.is(Element) orelse return false;
                    return el.getTag() == self._filter;
                },
                .selected_options => {
                    const el = node.is(Element) orelse return false;
                    const Option = Element.Html.Option;
                    const opt = el.is(Option) orelse return false;
                    return opt.getSelected();
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

                    if (el.getAttributeSafe(comptime .wrap("form"))) |form_attr| {
                        const form_id = self._filter.asElement().getAttributeSafe(comptime .wrap("id")) orelse return false;
                        return std.mem.eql(u8, form_attr, form_id);
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
                    return self._filter.asNode().contains(node);
                },
            }
        }

        fn isFormControl(el: *Element) bool {
            if (el._type != .html) return false;
            const html = el._type.html;
            return switch (html._type) {
                .input, .button, .select, .textarea => true,
                else => false,
            };
        }

        fn versionCheck(self: *Self, page: *const Page) bool {
            const current = page.version;
            if (current == self._cached_version) {
                return true;
            }

            self._tw.reset();
            self._last_index = 0;
            self._last_length = null;
            self._cached_version = current;
            return false;
        }

        const HTMLCollection = @import("HTMLCollection.zig");
        const NodeList = @import("NodeList.zig");

        pub fn runtimeGenericWrap(self: Self, page: *Page) !if (mode == .name) *NodeList else *HTMLCollection {
            const collection = switch (mode) {
                .name => return page._factory.create(NodeList{ ._data = .{ .name = self } }),
                .tag => HTMLCollection{ ._data = .{ .tag = self } },
                .tag_name => HTMLCollection{ ._data = .{ .tag_name = self } },
                .tag_name_ns => HTMLCollection{ ._data = .{ .tag_name_ns = self } },
                .class_name => HTMLCollection{ ._data = .{ .class_name = self } },
                .all_elements => HTMLCollection{ ._data = .{ .all_elements = self } },
                .child_elements => HTMLCollection{ ._data = .{ .child_elements = self } },
                .child_tag => HTMLCollection{ ._data = .{ .child_tag = self } },
                .selected_options => HTMLCollection{ ._data = .{ .selected_options = self } },
                .links => HTMLCollection{ ._data = .{ .links = self } },
                .anchors => HTMLCollection{ ._data = .{ .anchors = self } },
                .form => HTMLCollection{ ._data = .{ .form = self } },
            };
            return page._factory.create(collection);
        }
    };
}
