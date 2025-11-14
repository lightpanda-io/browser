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
const builtin = @import("builtin");

const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const Selector = @import("../selector/Selector.zig");

const Allocator = std.mem.Allocator;

const Mode = enum {
    tag,
    tag_name,
    class_name,
    child_elements,
};

const Filters = union(Mode) {
    tag: Element.Tag,
    tag_name: String,
    class_name: []const u8,
    child_elements,

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
        .tag, .tag_name, .class_name => TreeWalker.FullExcludeSelf,
        .child_elements => TreeWalker.Children,
    };
    return struct {
        _tw: TW,
        _filter: Filter,
        _last_index: usize,
        _last_length: ?u32,
        _cached_version: usize,
        // NodeLive doesn't use an arena directly, but the filter might have
        // used it (to own the string). So we take ownership of the arena so that
        // we can free it when we're freed.s
        _arena: ?Allocator,

        const Self = @This();

        pub fn init(arena: ?Allocator, root: *Node, filter: Filter, page: *Page) Self {
            return .{
                ._arena = arena,
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
            }

            // If we're here, it means it's either the first time we're called
            // or the DOM version has changed. Either way, the _tw should be
            // at the start position. It's important that self._last_index == 0
            // (which it always should be in these cases), because we're going to
            // reset _tw at the end of this, _last_index should always be 0 when
            // _tw is reset. Again, this should always be the case, but we're
            // asserting to make sure, else we'll have weird behavior, namely
            // the wrong item being returned for the wrong index.
            std.debug.assert(self._last_index == 0);

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
            if (page.document.getElementById(name)) |element| {
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
                const element_name = element.getAttributeSafe("name") orelse continue;
                if (std.mem.eql(u8, element_name, name)) {
                    return element;
                }
            }
            return null;
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
                    const el = node.is(Element) orelse return false;
                    const element_tag = el.getTagNameLower();
                    return std.mem.eql(u8, element_tag, self._filter.str());
                },
                .class_name => {
                    const el = node.is(Element) orelse return false;
                    const class_attr = el.getAttributeSafe("class") orelse return false;
                    return Selector.classAttributeContains(class_attr, self._filter);
                },
                .child_elements => return node._type == .element,
            }
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
        pub fn runtimeGenericWrap(self: Self, page: *Page) !*HTMLCollection {
            const collection = switch (mode) {
                .tag => HTMLCollection{ .data = .{ .tag = self } },
                .tag_name => HTMLCollection{ .data = .{ .tag_name = self } },
                .class_name => HTMLCollection{ .data = .{ .class_name = self } },
                .child_elements => HTMLCollection{ .data = .{ .child_elements = self } },
            };
            return page._factory.create(collection);
        }
    };
}
